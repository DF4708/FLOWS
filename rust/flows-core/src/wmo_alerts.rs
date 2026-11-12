// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! National weather alerts for Mexico, Central America and the Caribbean:
//! Swift's `WMOAlertParsing` before its rules moved here. Which country's
//! list answers for a point (and where a border is too close to say), the
//! flat scan of a list's items, a CAP file's shape and words, and an
//! alert's name in the words the risk rules read.
//!
//! Text follows Swift's own rules through [`crate::swift_text`]:
//! `range(of:)`, `contains` and `replacingOccurrences` are Foundation's,
//! `lowercased` and `==` the standard library's, a split on white space
//! goes by Characters. The diacritic folding stays in Swift (it is
//! Foundation's own table); the facade hands the folded text in. The two
//! readings in `namesHeavyRain` were regular expressions, matched by hand
//! here, both as ICU reads them, scalar by scalar: the amounts ran on
//! `NSRegularExpression`, and the class phrases, though they went through
//! `range(of:options: .regularExpression)`, carry a lookbehind, and the
//! frozen records show ICU's classes and `\b` there, not Swift Regex's
//! Characters.
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_wmo_alerts_oracle.tsv`.

use crate::families::alert_family_scored;
use crate::swift_text::{
    self, eq, graphemes, icu, lowercased, prefix_clusters, replacing, swift_double,
    swift_double_substring, swift_regex, trim_whitespace_newlines, ClusterIndex,
};

// ------------------------------------------------------------ which list

/// Hub feed codes with coarse national boxes `(min lat, max lat, min lon,
/// max lon)`, most specific first so a point in Belize or Costa Rica is not
/// taken by Mexico's wide box.
const FEEDS: [(&str, f64, f64, f64, f64); 7] = [
    ("bz-nms-en", 15.8, 18.5, -89.3, -87.3),
    ("cr-imn-es", 8.0, 11.3, -86.0, -82.5),
    ("pa-imhpa-es", 7.0, 9.7, -83.1, -77.1),
    ("do-indomet-es", 17.5, 20.1, -72.1, -68.3),
    ("jm-jms-en", 17.6, 18.7, -78.5, -76.1),
    ("tt-ttms-en", 10.0, 11.4, -62.1, -60.8),
    ("mx-smn-es", 14.3, 32.8, -118.5, -86.7),
];

/// The side of Belize's borders a point in its box is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BelizeSide {
    Belize,
    Mexico,
    Unsure,
}

/// The hub feed code for a point, or `None` outside every covered country
/// and wherever a border is too close to name one.
#[must_use]
pub fn feed_code(lat: f64, lon: f64) -> Option<&'static str> {
    for &(code, min_lat, max_lat, min_lon, max_lon) in &FEEDS {
        if !(lat >= min_lat && lat <= max_lat && lon >= min_lon && lon <= max_lon) {
            continue;
        }
        if code == "mx-smn-es" && south_of_mexico(lat, lon) {
            continue;
        }
        if code == "bz-nms-en" {
            match beside_belize(lat, lon) {
                BelizeSide::Mexico => continue,
                BelizeSide::Unsure => return None,
                BelizeSide::Belize => {}
            }
        }
        if code == "tt-ttms-en" && lat > 10.45 && lon < -61.8 {
            return None;
        }
        if code == "cr-imn-es" && beside_costa_rica(lat, lon) {
            return None;
        }
        return Some(code);
    }
    None
}

/// Whether a point in Mexico's box lies past its southern border, as steps.
#[must_use]
pub fn south_of_mexico(lat: f64, lon: f64) -> bool {
    if lat < 15.2 {
        return lon > -92.25;
    }
    if lat < 16.07 {
        return lon > -92.0;
    }
    if lat < 16.5 {
        return lon > -90.6;
    }
    if lat < 17.82 {
        return lon > -91.0;
    }
    false
}

/// Which side of Belize's borders a point in its box is on; within a tenth
/// of a degree of the Hondo, unsure.
#[must_use]
pub fn beside_belize(lat: f64, lon: f64) -> BelizeSide {
    if lat < 15.9 || lon < -89.15 {
        return BelizeSide::Unsure;
    }
    if lon < -88.88 {
        return if lat > 17.8 {
            BelizeSide::Unsure
        } else {
            BelizeSide::Belize
        };
    }
    if lon > -88.1 {
        return if lat > 18.2 {
            BelizeSide::Mexico
        } else {
            BelizeSide::Belize
        };
    }
    if lon > -88.3 {
        return if lat > 18.45 {
            BelizeSide::Unsure
        } else {
            BelizeSide::Belize
        };
    }
    let river = 17.90 + 1.07 * (lon + 88.88);
    if lat > river + 0.1 {
        return BelizeSide::Mexico;
    }
    if lat > river - 0.1 {
        BelizeSide::Unsure
    } else {
        BelizeSide::Belize
    }
}

/// A point in Costa Rica's box that may be Nicaragua or Panama.
#[must_use]
pub fn beside_costa_rica(lat: f64, lon: f64) -> bool {
    if lat > (if lon < -85.0 { 11.0 } else { 10.7 }) {
        return true;
    }
    lon > -83.1 && lat < 9.7
}

// ------------------------------------------------------------ tags

/// `<name>…</name>` in one text: Foundation's first `<name>`, then the
/// first `</name>` after it, the text between trimmed of white space and
/// line ends (scalars, both ends).
struct Tags<'a> {
    text: &'a str,
    index: ClusterIndex<'a>,
}

impl<'a> Tags<'a> {
    fn new(text: &'a str) -> Self {
        Tags {
            text,
            index: ClusterIndex::new(text),
        }
    }

    fn find_in(&self, needle: &str, from: usize) -> Option<(usize, usize)> {
        self.index.find_in(needle, from, self.text.len())
    }

    fn raw(&self, name: &str) -> Option<&'a str> {
        let (_, s) = self.find_in(&format!("<{name}>"), 0)?;
        let (e, _) = self.find_in(&format!("</{name}>"), s)?;
        Some(&self.text[s..e])
    }

    fn tag(&self, name: &str) -> Option<&'a str> {
        self.raw(name).map(trim_whitespace_newlines)
    }
}

/// `split(whereSeparator: \.isWhitespace)`: the Characters between white
/// space Characters, empty pieces dropped.
fn split_whitespace_characters(text: &str) -> Vec<&str> {
    split_characters(text, swift_regex::is_space)
}

/// `split(separator: ",")`: a Character equal to the one-scalar comma.
fn split_commas(text: &str) -> Vec<&str> {
    split_characters(text, |c| c == ",")
}

fn split_characters(text: &str, separator: impl Fn(&str) -> bool) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut at = 0;
    for c in graphemes(text) {
        if separator(c) {
            if at > start {
                out.push(&text[start..at]);
            }
            start = at + c.len();
        }
        at += c.len();
    }
    if at > start {
        out.push(&text[start..at]);
    }
    out
}

// ------------------------------------------------------------ RSS

/// One item of a service's list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RssItem {
    pub link: String,
    pub event: String,
    pub severity: String,
    pub expires: String,
    pub published: String,
}

/// RSS `<item>` blocks, then Atom `<entry>` blocks.
#[must_use]
pub fn parse_rss_items(xml: &str) -> Vec<RssItem> {
    let index = ClusterIndex::new(xml);
    let mut out = parse_items(xml, &index, "<item>", "</item>");
    out.extend(parse_items(xml, &index, "<entry>", "</entry>"));
    out
}

fn parse_items(xml: &str, index: &ClusterIndex<'_>, open: &str, close: &str) -> Vec<RssItem> {
    let mut out = Vec::new();
    let mut pos = 0;
    while let Some((_, ob)) = index.find_in(open, pos, xml.len()) {
        let Some((ca, cb)) = index.find_in(close, ob, xml.len()) else {
            break;
        };
        let body = Tags::new(&xml[ob..ca]);
        let link = body.tag("link").or_else(|| {
            let (_, l) = body.find_in("<link ", 0)?;
            let (_, h) = body.find_in("href=\"", l)?;
            let (q, _) = body.find_in("\"", h)?;
            Some(&body.text[h..q])
        });
        if let Some(link) = link.filter(|l| !l.is_empty()) {
            out.push(RssItem {
                link: link.to_string(),
                event: body
                    .tag("cap:event")
                    .or_else(|| body.tag("title"))
                    .unwrap_or("Weather alert")
                    .to_string(),
                severity: body.tag("cap:severity").unwrap_or("Moderate").to_string(),
                expires: body.tag("cap:expires").unwrap_or("").to_string(),
                published: body
                    .tag("pubDate")
                    .or_else(|| body.tag("updated"))
                    .unwrap_or("")
                    .to_string(),
            });
        }
        pos = cb;
    }
    out
}

// ------------------------------------------------------------ CAP

/// A point `(lat, lon)` in degrees.
pub type Point = (f64, f64);

/// A CAP file's shape and words.
#[derive(Clone, Debug, PartialEq)]
pub struct ParsedCap {
    pub event: String,
    pub severity: String,
    /// Every `<polygon>` with three points or more, one ring each.
    pub polygons: Vec<Vec<Point>>,
    pub area_desc: Option<String>,
    pub expires: Option<String>,
    pub effective: Option<String>,
    pub web: Option<String>,
    /// At most 280 Characters.
    pub description: Option<String>,
    /// Not a test, a cancellation or an all clear.
    pub is_live: bool,
    pub identifier: Option<String>,
    /// The identifiers of the earlier messages it replaces.
    pub references: Vec<String>,
}

/// CAP `<polygon>` text: `lat,lon` pairs parted by white space. A pair that
/// cannot be read makes no ring at all.
#[must_use]
pub fn polygon_coords(raw: &str) -> Vec<Point> {
    let mut ring = Vec::new();
    for pair in split_whitespace_characters(raw) {
        let xy = split_commas(pair);
        let (Some(lat), Some(lon)) = (
            xy.first().and_then(|s| swift_double_substring(s)),
            xy.get(1).and_then(|s| swift_double_substring(s)),
        ) else {
            return Vec::new();
        };
        if xy.len() != 2 {
            return Vec::new();
        }
        ring.push((lat, lon));
    }
    ring
}

/// The file with every `cap:` prefix taken off its tags, when it is an
/// alert file at all.
fn unprefixed(raw: &str) -> Option<String> {
    let xml = replacing(&replacing(raw, "<cap:", "<"), "</cap:", "</");
    swift_text::contains(&xml, "<alert").then_some(xml)
}

fn rings(tags: &Tags<'_>) -> Vec<Vec<Point>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while let Some((_, s)) = tags.find_in("<polygon>", pos) {
        let Some((e, eb)) = tags.find_in("</polygon>", s) else {
            break;
        };
        let ring = polygon_coords(trim_whitespace_newlines(&tags.text[s..e]));
        if ring.len() >= 3 {
            out.push(ring);
        }
        pos = eb;
    }
    out
}

/// Only the rings of a CAP file, `None` where [`parse_cap`] answers `None`.
#[must_use]
pub fn cap_polygons(raw: &str) -> Option<Vec<Vec<Point>>> {
    let xml = unprefixed(raw)?;
    Some(rings(&Tags::new(&xml)))
}

/// A CAP file, or `None` when it is not an alert file.
#[must_use]
pub fn parse_cap(raw: &str) -> Option<ParsedCap> {
    let xml = unprefixed(raw)?;
    let tags = Tags::new(&xml);
    let owned = |name: &str| tags.tag(name).map(str::to_string);
    let not = |name: &str, word: &str| tags.tag(name).is_none_or(|v| !eq(&lowercased(v), word));
    let live = tags
        .tag("status")
        .is_none_or(|s| eq(&lowercased(s), "actual"))
        && not("msgType", "cancel")
        && not("responseType", "allclear");
    let references = split_whitespace_characters(tags.tag("references").unwrap_or(""))
        .into_iter()
        .filter_map(|r| split_commas(r).get(1).map(|p| (*p).to_string()))
        .collect();
    Some(ParsedCap {
        event: tags.tag("event").unwrap_or("Weather alert").to_string(),
        severity: tags.tag("severity").unwrap_or("Moderate").to_string(),
        polygons: rings(&tags),
        area_desc: owned("areaDesc"),
        expires: owned("expires"),
        effective: owned("effective").or_else(|| owned("onset")),
        web: owned("web"),
        description: tags
            .tag("description")
            .map(|d| prefix_clusters(d, 280).to_string()),
        is_live: live,
        identifier: owned("identifier"),
        references,
    })
}

// ------------------------------------------------------------ risk words

/// A service's own name for an alert in the words the risk rules read.
/// `folded_event` is the event folded diacritic- and case-insensitively
/// (Swift's `folding`), `folded_rain_text` the same of the event, a space
/// and the detail (empty when there is none); [`names_heavy_rain`] reads
/// the second only for a rain notice that is not severe.
#[must_use]
pub fn event_in_risk_words(
    event: &str,
    folded_event: &str,
    severity: &str,
    folded_rain_text: &str,
) -> String {
    if event.is_empty() || alert_family_scored(event).is_some() {
        return event.to_string();
    }
    let e = lowercased(folded_event);
    let has = |words: &[&str]| words.iter().any(|w| swift_text::contains(&e, w));
    let sev = lowercased(severity);
    let strong = eq(&sev, "severe") || eq(&sev, "extreme");
    let pick = |warning: &str, other: &str| if strong { warning } else { other }.to_string();
    if has(&[
        "ciclon",
        "huracan",
        "tormenta tropical",
        "depresion tropical",
        "tropical",
    ]) {
        return pick("Tropical Storm Warning", "Tropical Storm Watch");
    }
    if has(&[
        "small craft",
        "seas",
        "marine",
        "oleaje",
        "mar de fondo",
        "marejada",
        "surf",
    ]) {
        return event.to_string();
    }
    if has(&["inunda", "riverine", "crecida", "desbordamiento"]) {
        return pick("Flood Warning", "Flood Advisory");
    }
    if has(&["lluvia", "rain"]) {
        if strong {
            return "Flood Warning".to_string();
        }
        let name = if names_heavy_rain(folded_rain_text) {
            "Flood Advisory"
        } else {
            "Rain Advisory"
        };
        return name.to_string();
    }
    if has(&["nevada", "nieve", "aguanieve"]) {
        return "Winter Weather Advisory".to_string();
    }
    if has(&["frente frio", "frio", "helada"]) {
        return "Cold Weather Advisory".to_string();
    }
    if has(&["calor", "hot spell", "hot weather"]) {
        return "Heat Advisory".to_string();
    }
    if has(&["viento", "gust"]) {
        return "Wind Advisory".to_string();
    }
    if has(&["tormenta", "electrica", "granizo", "adverse weather"]) {
        return pick("Severe Thunderstorm Warning", "Severe Thunderstorm Watch");
    }
    if has(&["niebla", "neblina"]) {
        return "Dense Fog Advisory".to_string();
    }
    event.to_string()
}

/// The least rain, in millimetres, that makes a rain notice a flood notice.
pub const FLOOD_RAIN_MILLIMETRES: f64 = 50.0;

/// Whether a notice's words put its rain at the flood threshold. `folded`
/// is the text already folded by Swift; it is lowercased here.
#[must_use]
pub fn names_heavy_rain(folded: &str) -> bool {
    let t = lowercased(folded);
    if ["very heavy rain", "torrential", "extreme rain"]
        .iter()
        .any(|w| swift_text::contains(&t, w))
    {
        return true;
    }
    let sc = Scalars::new(&t);
    sc.class_said() || sc.amounts_reach(FLOOD_RAIN_MILLIMETRES)
}

// ---- ICU, scalar by scalar

/// The rain words, each optional ending spelled out.
const RAIN_WORDS: [&str; 8] = [
    "lluvia",
    "lluvias",
    "precipitacion",
    "precipitaciones",
    "chubasco",
    "chubascos",
    "aguacero",
    "aguaceros",
];
/// The heavy classes, each optional ending spelled out.
const HEAVY_WORDS: [&str; 8] = [
    "muy fuerte",
    "muy fuertes",
    "intensa",
    "intensas",
    "torrencial",
    "torrenciales",
    "extraordinaria",
    "extraordinarias",
];
/// `(?!sin\b|vientos?\b|rachas?\b|oleaje\b|olas\b|mar\b)`, spelled out.
const NOT_BETWEEN: [&str; 8] = [
    "sin", "viento", "vientos", "racha", "rachas", "oleaje", "olas", "mar",
];
const UNITS: [&str; 4] = ["mm", "milimetros", "millimeters", "millimetres"];
const RANGE_WORDS: [&str; 4] = ["a", "to", "-", "\u{2013}"];

/// A text as ICU reads it: its scalars, with ICU's classes and `\b`.
///
/// Every `\s+`, `\s*`, `\d+` and `[a-z]+` below is followed by something it
/// cannot take, so its longest run is the only one that can match, and
/// only the longest is tried.
struct Scalars {
    s: Vec<char>,
}

impl Scalars {
    fn new(t: &str) -> Self {
        Scalars {
            s: t.chars().collect(),
        }
    }

    fn digit(&self, i: usize) -> bool {
        self.s.get(i).is_some_and(|&c| icu::is_digit(c))
    }

    fn space(&self, i: usize) -> bool {
        self.s.get(i).is_some_and(|&c| icu::is_space(c))
    }

    fn az(&self, i: usize) -> bool {
        self.s.get(i).is_some_and(char::is_ascii_lowercase)
    }

    /// ICU's `\b` (see `maneuver`): never before a scalar it looks
    /// through; otherwise a word scalar on exactly one side.
    fn boundary(&self, pos: usize) -> bool {
        let here = match self.s.get(pos) {
            Some(&c) if icu::is_skip(c) => return false,
            Some(&c) => icu::is_word(c),
            None => false,
        };
        let before = self.s[..pos.min(self.s.len())]
            .iter()
            .rev()
            .find(|&&c| !icu::is_skip(c))
            .is_some_and(|&c| icu::is_word(c));
        here != before
    }

    fn literal(&self, pos: usize, word: &str) -> Option<usize> {
        let mut at = pos;
        for w in word.chars() {
            if self.s.get(at) != Some(&w) {
                return None;
            }
            at += 1;
        }
        Some(at)
    }

    fn ends(&self, i: usize, words: &[&str]) -> Vec<usize> {
        words.iter().filter_map(|w| self.literal(i, w)).collect()
    }

    fn run(&self, i: usize, class: impl Fn(&Self, usize) -> bool) -> usize {
        let mut at = i;
        while class(self, at) {
            at += 1;
        }
        at
    }

    /// `\s+`.
    fn spaces1(&self, i: usize) -> Option<usize> {
        let at = self.run(i, Self::space);
        (at > i).then_some(at)
    }

    /// `\s*`.
    fn spaces0(&self, i: usize) -> usize {
        self.run(i, Self::space)
    }

    /// `\d+`.
    fn digits(&self, i: usize) -> Option<usize> {
        let at = self.run(i, Self::digit);
        (at > i).then_some(at)
    }

    // -- the class said of the rain

    /// `(?!sin\b|…)[a-z]+`.
    fn other(&self, i: usize) -> Option<usize> {
        if NOT_BETWEEN
            .iter()
            .any(|w| self.literal(i, w).is_some_and(|e| self.boundary(e)))
        {
            return None;
        }
        let at = self.run(i, Self::az);
        (at > i).then_some(at)
    }

    /// `(?<!\bsin\s)` at `p`: `\s` is one scalar, so the only place the
    /// "sin" can start is four scalars back.
    fn not_after_sin(&self, p: usize) -> bool {
        !(p >= 4
            && self.literal(p - 4, "sin") == Some(p - 1)
            && self.space(p - 1)
            && self.boundary(p - 4))
    }

    /// `(?:\s+ OTHER){k,4}? \s+ HEAVY \b` from `r`.
    fn tail(&self, r: usize, k: usize) -> bool {
        let Some(s) = self.spaces1(r) else {
            return false;
        };
        if self.ends(s, &HEAVY_WORDS).iter().any(|&e| self.boundary(e)) {
            return true;
        }
        k < 4 && self.other(s).is_some_and(|e| self.tail(e, k + 1))
    }

    /// Either class pattern matches somewhere:
    ///
    /// 1. `(?<!\bsin\s)\b RAIN (?:\s+ OTHER){0,4}? \s+ HEAVY \b`
    /// 2. `(?<!\bsin\s)\b HEAVY \s+ RAIN`
    ///
    /// Only whether one matches is read, so every way through is tried
    /// rather than the regex's order.
    fn class_said(&self) -> bool {
        (0..self.s.len()).any(|p| {
            if !(self.not_after_sin(p) && self.boundary(p)) {
                return false;
            }
            self.ends(p, &RAIN_WORDS).iter().any(|&r| self.tail(r, 0))
                || self.ends(p, &HEAVY_WORDS).iter().any(|&e| {
                    self.spaces1(e)
                        .is_some_and(|s| !self.ends(s, &RAIN_WORDS).is_empty())
                })
        })
    }

    // -- the amounts

    /// `\d+(?:[.,]\d+)?`: where it can end, the fraction first.
    fn number(&self, i: usize) -> Vec<usize> {
        let Some(d) = self.digits(i) else {
            return Vec::new();
        };
        let mut out = Vec::with_capacity(2);
        if matches!(self.s.get(d), Some('.' | ',')) {
            if let Some(f) = self.digits(d + 1) {
                out.push(f);
            }
        }
        out.push(d);
        out
    }

    /// `\s*UNIT\b` at `x`: where the match ends.
    fn unit(&self, x: usize) -> Option<usize> {
        let y = self.spaces0(x);
        UNITS
            .iter()
            .filter_map(|u| self.literal(y, u))
            .find(|&z| self.boundary(z))
    }

    /// Everything after group 1, ending at `g`: where the match ends.
    fn rest(&self, g: usize) -> Option<usize> {
        let a = self.spaces0(g);
        let ranged = RANGE_WORDS
            .iter()
            .find_map(|w| self.literal(a, w))
            .and_then(|b| {
                let c = self.spaces0(b);
                self.number(c).into_iter().find_map(|e| self.unit(e))
            });
        ranged.or_else(|| self.unit(g))
    }

    /// The match starting at `s`: group 1's end and the match's end.
    fn match_at(&self, s: usize) -> Option<(usize, usize)> {
        self.number(s)
            .into_iter()
            .find_map(|g| self.rest(g).map(|z| (g, z)))
    }

    /// `(\d+(?:[.,]\d+)?)(?:\s*(?:a|to|-|–)\s*\d+(?:[.,]\d+)?)?\s*UNIT\b`
    /// as `NSRegularExpression.matches` walks it: leftmost matches, none
    /// overlapping, each in the regex's own order (the optional parts tried
    /// present first, the alternatives in order). Whether any group, its
    /// comma read as a point, is `least` or more. The group is scalars, so
    /// its `Range` in the Swift string always exists, even where it starts
    /// inside a Character (after a prepended mark).
    fn amounts_reach(&self, least: f64) -> bool {
        let n = self.s.len();
        let mut pos = 0;
        while pos < n {
            let Some((s, (g, z))) = (pos..n).find_map(|s| self.match_at(s).map(|m| (s, m))) else {
                return false;
            };
            let group: String = self.s[s..g].iter().collect();
            if swift_double(&replacing(&group, ",", ".")).is_some_and(|v| v >= least) {
                return true;
            }
            pos = z;
        }
        false
    }
}
