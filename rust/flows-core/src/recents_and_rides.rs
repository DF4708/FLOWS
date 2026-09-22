// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Places typed or planned before, rental counters at the far end of a
//! transit trip, and the emergency radio's station rules —
//! `DestinationSearch.swift` (`CoordinateInput`, `RecentDestinations`,
//! `DestinationSearch.blend`), `TransitItinerary.swift` (`RentalCars`) and
//! `TruckerRadio.swift`'s static rules at commit c206b98, the last before
//! their facade switch. The ride estimates from the same transit file live
//! beside the fares in [`crate::travel_modes`].
//!
//! | here | Swift |
//! |---|---|
//! | [`parse_coordinate`] | `CoordinateInput.parse` |
//! | [`recent_score`], [`merged_recents`], [`matching_recents`], [`recordable_name`], [`RECENTS_CAP`] | `RecentDestinations` |
//! | [`blend_suggestions`] | `DestinationSearch.blend` |
//! | [`RENTAL_BRANDS`], [`rental_brand_rank`], [`rental_booking_site`], [`recommend_rentals`] | `RentalCars` |
//! | [`radio_purpose`], [`radio_is_car_band`], [`radio_advance`], [`radio_state_code`], [`radio_position`] | `TruckerRadio` |
//! | [`relay_spans`], [`relay_callsign`] | `TruckerRadio.relayChannels` (the relay directory's scrape) |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_recents_and_rides_oracle.tsv`.
//! Every text rule is Swift's, from [`st`]: `uppercased()` and `lowercased()`
//! map scalar by scalar (`ß` becomes `SS`); `==`, `Set` membership and
//! `Dictionary` keys compare by canonical equivalence; `split(separator:)`,
//! `first`, `last`, `removeFirst`, `firstIndex(of:)`, `hasPrefix` and
//! distances work on grapheme clusters; Foundation's `contains` and
//! `replacingOccurrences` match whole clusters; `trimmingCharacters` trims
//! scalars; `Double(String)` is `strtod` behind Swift's checks. Sorts are
//! Swift's own ([`swift_sort_by`]); `max` is Swift's ([`smax`]);
//! `pow(0.5, x)` is `exp2(-x)`, as the Release build computes it.
//!
//! One Swift result is not reproducible and is fixed here instead:
//! `RentalCars.recommend` sorted `Dictionary.values`, so offices of one brand
//! rank whose miles do not order (equal, or not a number) came out in the
//! order of that launch's hash seed. [`recommend_rentals`] keeps them in the
//! order their brands first appeared.
//!
//! What stays in Swift: the pasted point's display name, the stores'
//! encrypted files, Apple's search completer, the purposes' and ride steps'
//! wording, booking and stream links, the directory fetch, and the player.
//! The scrape's rules followed from the commit that made them a pure static,
//! pinned by `swift_relay_scrape_oracle.tsv`.

use crate::fcmp::smax;
use crate::hazard_feeds::STATE_BOXES;
use crate::learning::swift_sort_by;
use crate::swift_text as st;

// ============================================================ CoordinateInput

/// The hemisphere a cluster names, when it is exactly `N`, `S`, `E` or `W`
/// (Swift's `"NSEW".contains(character)`; no other cluster is canonically
/// equivalent to one of those letters).
fn hemisphere(cluster: &str) -> Option<char> {
    match cluster {
        "N" => Some('N'),
        "S" => Some('S'),
        "E" => Some('E'),
        "W" => Some('W'),
        _ => None,
    }
}

/// A pasted coordinate: `Some((latitude, longitude))` only when the WHOLE
/// text is exactly two coordinate components. Hemisphere letters may prefix
/// or suffix either component, or stand alone beside it; `S` and `W` negate;
/// without letters the order is latitude, longitude. Out-of-range values,
/// extra words and a third number are not a coordinate.
///
/// Deterministic; panics: none.
#[must_use]
pub fn parse_coordinate(text: &str) -> Option<(f64, f64)> {
    let cleaned = st::replacing(
        &st::replacing(&st::replacing(&st::uppercased(text), ",", " "), ";", " "),
        "°",
        " ",
    );
    let mut comps: Vec<(f64, Option<char>)> = Vec::new();
    // A hemisphere letter that arrives BEFORE its number ("N 43.07").
    let mut pending: Option<char> = None;
    for token in st::split_spaces(&cleaned) {
        let clusters: Vec<&str> = st::graphemes(token).collect();
        let (mut lo, mut hi) = (0, clusters.len());
        let mut hemi = None;
        if let Some(h) = clusters.first().and_then(|c| hemisphere(c)) {
            hemi = Some(h);
            lo = 1;
        }
        if hi > lo {
            if let Some(h) = hemisphere(clusters[hi - 1]) {
                if hemi.is_some() {
                    return None; // "N43W"
                }
                hemi = Some(h);
                hi -= 1;
            }
        }
        if lo == hi {
            // A hemisphere letter as its own token labels the number beside it.
            let h = hemi?;
            match comps.last_mut() {
                Some(last) if last.1.is_none() => last.1 = Some(h),
                _ if pending.is_none() => pending = Some(h),
                _ => return None,
            }
            continue;
        }
        let value = st::swift_double(&clusters[lo..hi].concat())?;
        comps.push((value, hemi.or(pending)));
        pending = None;
    }
    if comps.len() != 2 || pending.is_some() {
        return None;
    }
    let signed = |(value, hemi): (f64, Option<char>)| match hemi {
        Some('S' | 'W') => -value.abs(),
        Some('N' | 'E') => value.abs(),
        _ => value,
    };
    let (mut lat, mut lon) = (None, None);
    for &c in &comps {
        match c.1 {
            Some('N' | 'S') => {
                if lat.is_some() {
                    return None;
                }
                lat = Some(signed(c));
            }
            Some('E' | 'W') => {
                if lon.is_some() {
                    return None;
                }
                lon = Some(signed(c));
            }
            _ => {}
        }
    }
    // Letter-free components fill the remaining slots in lat, lon order.
    let mut rest = comps.iter().filter(|c| c.1.is_none()).map(|&c| signed(c));
    if lat.is_none() {
        lat = rest.next();
    }
    if lon.is_none() {
        lon = rest.next();
    }
    if rest.next().is_some() {
        return None;
    }
    let (lat, lon) = (lat?, lon?);
    (lat.abs() <= 90.0 && lon.abs() <= 180.0).then_some((lat, lon))
}

// ============================================================ RecentDestinations

/// How many recent places are kept.
pub const RECENTS_CAP: usize = 20;

/// One remembered place. Times are seconds since 2001-01-01 (Foundation's
/// reference date).
#[derive(Debug, Clone, PartialEq)]
pub struct Recent {
    /// The name as the driver last planned it.
    pub name: String,
    /// Degrees.
    pub latitude: f64,
    /// Degrees.
    pub longitude: f64,
    /// When it was last planned.
    pub last_used: f64,
    /// How many plans it has had.
    pub uses: i64,
}

/// Frequency times a two-week recency half-life: the daily coffee run
/// outranks last month's one-off.
///
/// Deterministic; panics: none.
#[must_use]
pub fn recent_score(uses: i64, last_used: f64, now: f64) -> f64 {
    let age_days = smax(now - last_used, 0.0) / 86_400.0;
    #[allow(clippy::cast_precision_loss)] // Swift's Double(Int) rounds the same way
    let uses = uses as f64;
    uses * (age_days / -14.0).exp2()
}

/// Remember a planned place: an entry whose lowercased name matches gains a
/// use and takes the new name, place and time; otherwise the place joins.
/// Then rank by [`recent_score`] and keep [`RECENTS_CAP`].
///
/// Deterministic; panics: none. (Swift trapped when a count of uses reached
/// `Int.max`; this saturates.)
#[must_use]
pub fn merged_recents(list: &[Recent], new: &Recent, now: f64) -> Vec<Recent> {
    let (uses, order) = merged_recent_order(list, new, now);
    order
        .into_iter()
        .map(|slot| match slot {
            Some(i) => list[i].clone(),
            None => Recent {
                uses,
                ..new.clone()
            },
        })
        .collect()
}

/// [`merged_recents`] as the bridge sends it: the merged place's use count,
/// then the new order, `Some(i)` for the old list's place `i` unchanged and
/// `None` for the merged place (the new name, place and time with that
/// count).
///
/// Deterministic; panics: none.
#[must_use]
pub fn merged_recent_order(list: &[Recent], new: &Recent, now: f64) -> (i64, Vec<Option<usize>>) {
    let id = st::lowercased(&new.name);
    let held = list
        .iter()
        .position(|e| st::eq(&st::lowercased(&e.name), &id));
    let uses = held.map_or(new.uses, |i| list[i].uses.saturating_add(1));
    // The places as Swift's array holds them after the merge: the matched
    // place replaced where it stood, or the new one appended.
    let mut slots: Vec<Option<usize>> = (0..list.len()).map(Some).collect();
    match held {
        Some(i) => slots[i] = None,
        None => slots.push(None),
    }
    let scores: Vec<f64> = slots
        .iter()
        .map(|slot| match slot {
            Some(i) => recent_score(list[*i].uses, list[*i].last_used, now),
            None => recent_score(uses, new.last_used, now),
        })
        .collect();
    let mut order: Vec<usize> = (0..slots.len()).collect();
    swift_sort_by(&mut order, |a, b| scores[a] > scores[b]);
    (
        uses,
        order
            .into_iter()
            .take(RECENTS_CAP)
            .map(|k| slots[k])
            .collect(),
    )
}

/// The name a plan is remembered under, or `None` when it is not worth
/// remembering: blank once spaces and tabs are trimmed, or "current location"
/// in any case.
///
/// Deterministic; panics: none.
#[must_use]
pub fn recordable_name(name: &str) -> Option<&str> {
    let trimmed = st::trim_whitespace(name);
    (!trimmed.is_empty() && !st::eq(&st::lowercased(trimmed), "current location"))
        .then_some(trimmed)
}

/// The recent places matching a typed fragment, best first, as indices into
/// `names` (already in rank order): all of them for a blank fragment,
/// otherwise those whose lowercased name contains the trimmed, lowercased
/// fragment; at most `limit`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn matching_recents(names: &[&str], fragment: &str, limit: usize) -> Vec<usize> {
    let f = st::lowercased(st::trim_whitespace(fragment));
    (0..names.len())
        .filter(|&i| f.is_empty() || st::contains(&st::lowercased(names[i]), &f))
        .take(limit)
        .collect()
}

// ============================================================ DestinationSearch

/// Where a blended suggestion came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Blended {
    /// A locally resolved row, by its index.
    Pinned(usize),
    /// An Apple completion, by its index.
    Completion(usize),
}

/// Pinned local rows first, then the completions whose lowercased title no
/// pinned title matches, at most `cap`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn blend_suggestions(pinned: &[&str], completions: &[&str], cap: usize) -> Vec<Blended> {
    let taken: Vec<String> = pinned.iter().map(|t| st::lowercased(t)).collect();
    (0..pinned.len())
        .map(Blended::Pinned)
        .chain(
            (0..completions.len())
                .filter(|&i| {
                    let title = st::lowercased(completions[i]);
                    !taken.iter().any(|t| st::eq(t, &title))
                })
                .map(Blended::Completion),
        )
        .take(cap)
        .collect()
}

// ============================================================ RentalCars

/// US rental brands, biggest first; an unknown agency ranks after all of
/// them.
pub const RENTAL_BRANDS: [&str; 12] = [
    "enterprise",
    "hertz",
    "avis",
    "budget",
    "national",
    "alamo",
    "sixt",
    "thrifty",
    "dollar",
    "zipcar",
    "turo",
    "u-haul",
];

/// Each brand's own reservation site, in [`RENTAL_BRANDS`] order.
pub const RENTAL_SITES: [&str; 12] = [
    "https://www.enterprise.com",
    "https://www.hertz.com",
    "https://www.avis.com",
    "https://www.budget.com",
    "https://www.nationalcar.com",
    "https://www.alamo.com",
    "https://www.sixt.com",
    "https://www.thrifty.com",
    "https://www.dollar.com",
    "https://www.zipcar.com",
    "https://turo.com",
    "https://www.uhaul.com",
];

/// Where a traveller can compare rental prices across brands, with FLOWS's
/// partner tag on it (DiscoverCars, Travel Drive GmbH, Zug — the programme
/// the owner joined). A booking made through this link is credited to FLOWS.
///
/// The tag is not a secret: it travels in the URL of every link a partner
/// publishes, which is the whole point of it.
pub const RENTAL_COMPARE_URL: &str = "https://www.discovercars.com/?a_aid=FAWN";

/// FLOWS's partner code, the tag that credits a booking to the app.
pub const RENTAL_PARTNER_CODE: &str = "FAWN";

/// A part of a landing-page address: lowercase, accents dropped to their
/// plain letters, anything else a hyphen, no hyphen doubled or dangling.
/// "St. Louis" → "st-louis", "Montréal" → "montreal".
fn slug(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in st::lowercased(text).chars() {
        let plain = match ch {
            'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'í' | 'ì' | 'î' | 'ï' => 'i',
            'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
            'ú' | 'ù' | 'û' | 'ü' => 'u',
            'ñ' => 'n',
            'ç' => 'c',
            other => other,
        };
        if plain.is_ascii_alphanumeric() {
            out.push(plain);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// The country part of a landing-page address: the US is split by STATE
/// ("usa-wisconsin"), Canada and Mexico are whole. `region` is the state's
/// name or its two-letter code; anything else has no address of its own.
fn rental_country_slug(country: &str, region: &str) -> Option<String> {
    match st::lowercased(country).as_str() {
        "us" | "usa" | "united states" => {
            let region = st::lowercased(region);
            let region = region.trim().trim_start_matches("us-").trim();
            if region.is_empty() {
                return None;
            }
            // A code ("WI") resolves through the state table; a full name is
            // already what the address wants.
            let name = if region.len() == 2 {
                crate::places_text::STATE_NAMES
                    .iter()
                    .find(|(_, code)| st::lowercased(code) == region)
                    .map(|(name, _)| (*name).to_string())?
            } else {
                region.to_string()
            };
            Some(format!("usa-{}", slug(&name)))
        }
        "ca" | "canada" => Some("canada".to_string()),
        "mx" | "mexico" => Some("mexico".to_string()),
        _ => None,
    }
}

/// Where to compare rental prices FOR ONE PLACE, with FLOWS's partner tag:
/// "https://www.discovercars.com/usa-wisconsin/milwaukee?a_aid=FAWN".
///
/// The address is the one DiscoverCars' own landing-page generator builds
/// (country or US state, then city). A place whose country or state FLOWS
/// does not know falls back to [`RENTAL_COMPARE_URL`], which always works.
///
/// Deterministic; allocates the address; panics: none.
#[must_use]
pub fn rental_landing_url(country: &str, region: &str, city: &str) -> String {
    let city = slug(city);
    let Some(country_slug) = rental_country_slug(country, region).filter(|_| !city.is_empty())
    else {
        return RENTAL_COMPARE_URL.to_string();
    };
    format!("https://www.discovercars.com/{country_slug}/{city}?a_aid={RENTAL_PARTNER_CODE}")
}

/// The first brand whose name the lowercased office name contains, as an
/// index into [`RENTAL_BRANDS`]; its length for no name, an empty one or an
/// unknown agency.
///
/// Deterministic; panics: none.
#[must_use]
pub fn rental_brand_rank(name: Option<&str>) -> usize {
    let Some(name) = name else {
        return RENTAL_BRANDS.len();
    };
    let lower = st::lowercased(name);
    if lower.is_empty() {
        return RENTAL_BRANDS.len();
    }
    RENTAL_BRANDS
        .iter()
        .position(|brand| st::contains(&lower, brand))
        .unwrap_or(RENTAL_BRANDS.len())
}

/// The reservation site for a recognised brand; `None` for no name or an
/// unknown agency.
///
/// Deterministic; panics: none.
#[must_use]
pub fn rental_booking_site(name: Option<&str>) -> Option<&'static str> {
    let lower = st::lowercased(name?);
    RENTAL_BRANDS
        .iter()
        .position(|brand| st::contains(&lower, brand))
        .map(|i| RENTAL_SITES[i])
}

/// The offices worth showing, as indices: the nearest office per brand (an
/// unknown agency is its own brand, by lowercased name), biggest brand
/// first, then nearest, at most `limit`. An office no nearer than the one
/// already held for its brand never replaces it. Offices that do not order
/// keep the order their brands first appeared (see the module notes).
///
/// Deterministic; panics: none. `names` and `miles` are parallel; extra
/// entries in the longer are ignored.
#[must_use]
pub fn recommend_rentals(names: &[&str], miles: &[f64], limit: usize) -> Vec<usize> {
    let count = names.len().min(miles.len());
    // (rank, brand key, held office), in the order the keys first appeared.
    let mut held: Vec<(usize, String, usize)> = Vec::new();
    for i in 0..count {
        let rank = rental_brand_rank(Some(names[i]));
        let key = if rank < RENTAL_BRANDS.len() {
            RENTAL_BRANDS[rank].to_string()
        } else {
            st::lowercased(names[i])
        };
        match held.iter_mut().find(|h| st::eq(&h.1, &key)) {
            Some(h) if miles[h.2] <= miles[i] => {}
            Some(h) => h.2 = i,
            None => held.push((rank, key, i)),
        }
    }
    let mut order: Vec<(usize, usize)> = held.iter().map(|h| (h.0, h.2)).collect();
    swift_sort_by(&mut order, |a, b| {
        if a.0 == b.0 {
            miles[a.1] < miles[b.1]
        } else {
            a.0 < b.0
        }
    });
    order.into_iter().take(limit).map(|(_, i)| i).collect()
}

// ============================================================ TruckerRadio

/// Why a driver would tune a cab-radio guide entry, as a code the Swift words:
/// 0 traffic, 1 west-coast traffic, 2 emergency help, 3 weather alerts,
/// 4 road work alerts.
///
/// Deterministic; panics: none.
#[must_use]
pub fn radio_purpose(channel: &str) -> u8 {
    if st::has_prefix(channel, "CB 19") {
        0
    } else if st::has_prefix(channel, "CB 17") {
        1
    } else if st::has_prefix(channel, "CB 9") {
        2
    } else if st::has_prefix(channel, "NOAA") {
        3
    } else {
        4
    }
}

/// Whether a normal car radio can tune the guide entry (the highway advisory
/// band).
///
/// Deterministic; panics: none.
#[must_use]
pub fn radio_is_car_band(channel: &str) -> bool {
    st::has_prefix(channel, "Highway Advisory")
}

/// A wrap-around step through a station queue; 0 for an empty queue.
///
/// Deterministic; panics: none. (Swift trapped when `index + step`
/// overflowed; this wraps.)
#[must_use]
pub fn radio_advance(index: i64, count: i64, step: i64) -> i64 {
    if count <= 0 {
        return 0;
    }
    let raw = index.wrapping_add(step) % count;
    if raw < 0 {
        raw + count
    } else {
        raw
    }
}

/// The state code at the start of a relay name ("NOAA WX AL-Mobile: KEC61"
/// gives "AL"): every "NOAA WX " removed, then the two clusters before the
/// first "-", uppercased; `None` when the first dash is not third.
///
/// Deterministic; panics: none.
#[must_use]
pub fn radio_state_code(name: &str) -> Option<String> {
    let name = st::replacing(name, "NOAA WX ", "");
    let clusters: Vec<&str> = st::graphemes(&name).collect();
    let dash = clusters.iter().position(|&c| st::eq(c, "-"))?;
    (dash == 2).then(|| st::uppercased(&clusters[..2].concat()))
}

/// Where a transmitter is: its own coordinates when it has both, `true`
/// for exact; otherwise the middle of its state's box, `false`; `None`
/// when neither is known.
///
/// Deterministic; panics: none.
#[must_use]
pub fn radio_position(
    name: &str,
    latitude: Option<f64>,
    longitude: Option<f64>,
) -> Option<(f64, f64, bool)> {
    if let (Some(la), Some(lo)) = (latitude, longitude) {
        return Some((la, lo, true));
    }
    let code = radio_state_code(name)?;
    let &(_, south, west, north, east) = STATE_BOXES.iter().find(|b| st::eq(b.0, &code))?;
    Some(((south + north) / 2.0, (west + east) / 2.0, false))
}

// ============================================================ the relay directory

/// Where a relay's stream link must start to count.
pub const RELAY_URL_PREFIX: &str = "https://radio.weatherusa.net/NWR/";

/// Fewer relays than this is a page that did not parse, not a directory that
/// shrank.
pub const MIN_RELAYS: usize = 10;

/// What a relay's name starts with; its label follows.
pub const RELAY_NAME_PREFIX: &str = "NOAA WX ";

/// One relay the directory page lists, as byte ranges into the page: its
/// stream link and its label (trimmed), and the bundled station whose
/// coordinates it carries, if any.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RelaySpan {
    /// The stream link, `start..end`.
    pub url: (usize, usize),
    /// The label, trimmed of whitespace and newlines, `start..end`.
    pub label: (usize, usize),
    /// The bundled station whose coordinates this relay carries.
    pub bundled: Option<usize>,
}

/// The callsign at the end of a station name: the last piece between colons
/// (Swift's `split(separator: ":")`, empty pieces dropped), trimmed of spaces
/// and tabs; `None` when the name has no piece.
///
/// Deterministic; panics: none.
#[must_use]
pub fn relay_callsign(name: &str) -> Option<&str> {
    let mut last = None;
    let (mut start, mut pos) = (0, 0);
    for cluster in st::graphemes(name) {
        if cluster == ":" {
            if pos > start {
                last = Some(&name[start..pos]);
            }
            start = pos + cluster.len();
        }
        pos += cluster.len();
    }
    if pos > start {
        last = Some(&name[start..pos]);
    }
    last.map(st::trim_whitespace)
}

/// The byte offset of the first cluster that is a double quote.
fn first_quote(text: &str) -> Option<usize> {
    let mut pos = 0;
    for cluster in st::graphemes(text) {
        if cluster == "\"" {
            return Some(pos);
        }
        pos += cluster.len();
    }
    None
}

/// The NOAA relays the weatherusa directory page lists: the page split at
/// every `<option value="`; a piece counts when it starts with
/// [`RELAY_URL_PREFIX`] and has a closing quote; the link is what comes
/// before that quote, and a link seen before is skipped; the label is what
/// lies between the piece's first `>` and the next `<`, trimmed, and must not
/// be empty. Each relay carries the coordinates of the first bundled station
/// that has both coordinates and shares its callsign (the name being
/// [`RELAY_NAME_PREFIX`] and the label). `None` when fewer than
/// [`MIN_RELAYS`] are found.
///
/// `bundled_names` and `bundled_located` are parallel: whether each bundled
/// station has both coordinates.
///
/// Deterministic; panics: none.
#[must_use]
pub fn relay_spans(
    html: &str,
    bundled_names: &[&str],
    bundled_located: &[bool],
) -> Option<Vec<RelaySpan>> {
    // Foundation's components(separatedBy:), keeping each piece's place.
    let index = st::ClusterIndex::new(html);
    let separator = "<option value=\"";
    let mut pieces: Vec<(usize, usize)> = Vec::new();
    let mut pos = 0;
    while let Some((a, b)) = index.find_in(separator, pos, html.len()) {
        pieces.push((pos, a));
        pos = b;
    }
    pieces.push((pos, html.len()));

    let mut spans: Vec<RelaySpan> = Vec::new();
    let mut seen: Vec<&str> = Vec::new();
    for (start, end) in pieces {
        let chunk = &html[start..end];
        if !st::has_prefix(chunk, RELAY_URL_PREFIX) {
            continue;
        }
        let Some(url_end) = first_quote(chunk) else {
            continue;
        };
        let url = &chunk[..url_end];
        if seen.iter().any(|s| st::eq(s, url)) {
            continue;
        }
        seen.push(url);
        let Some((_, after_gt)) = st::find(chunk, ">") else {
            continue;
        };
        let Some((lt, _)) = st::find_in(chunk, "<", after_gt, chunk.len()) else {
            continue;
        };
        let raw = &chunk[after_gt..lt];
        let lead = raw.len() - raw.trim_start_matches(st::is_whitespace_or_newline).len();
        let label = st::trim_whitespace_newlines(raw);
        if label.is_empty() {
            continue;
        }
        let label_start = start + after_gt + lead;
        spans.push(RelaySpan {
            url: (start, start + url_end),
            label: (label_start, label_start + label.len()),
            bundled: None,
        });
    }
    if spans.len() < MIN_RELAYS {
        return None;
    }
    // The first bundled station per callsign that has both coordinates.
    let mut calls: Vec<(&str, usize)> = Vec::new();
    for (i, name) in bundled_names.iter().enumerate() {
        if !bundled_located.get(i).copied().unwrap_or(false) {
            continue;
        }
        if let Some(call) = relay_callsign(name) {
            if !calls.iter().any(|c| st::eq(c.0, call)) {
                calls.push((call, i));
            }
        }
    }
    for span in &mut spans {
        let name = format!("{RELAY_NAME_PREFIX}{}", &html[span.label.0..span.label.1]);
        if let Some(call) = relay_callsign(&name) {
            span.bundled = calls.iter().find(|c| st::eq(c.0, call)).map(|c| c.1);
        }
    }
    Some(spans)
}

#[cfg(test)]
mod tests {
    /// The address DiscoverCars' own landing-page generator builds for a
    /// place, with FLOWS's partner tag — checked against what that generator
    /// produced for Milwaukee, Wisconsin.
    #[test]
    fn a_rental_landing_page_is_named_for_its_place() {
        use super::{rental_landing_url, RENTAL_COMPARE_URL};
        assert_eq!(
            rental_landing_url("US", "WI", "Milwaukee"),
            "https://www.discovercars.com/usa-wisconsin/milwaukee?a_aid=FAWN"
        );
        // The state may arrive as a name, a code, or the way a placemark
        // writes it; the city may carry punctuation or accents.
        assert_eq!(
            rental_landing_url("US", "Wisconsin", "Milwaukee"),
            rental_landing_url("US", "US-WI", "milwaukee")
        );
        assert_eq!(
            rental_landing_url("US", "MO", "St. Louis"),
            "https://www.discovercars.com/usa-missouri/st-louis?a_aid=FAWN"
        );
        assert_eq!(
            rental_landing_url("US", "NY", "New York"),
            "https://www.discovercars.com/usa-new-york/new-york?a_aid=FAWN"
        );
        assert_eq!(
            rental_landing_url("CA", "", "Montréal"),
            "https://www.discovercars.com/canada/montreal?a_aid=FAWN"
        );
        assert_eq!(
            rental_landing_url("MX", "", "Cancún"),
            "https://www.discovercars.com/mexico/cancun?a_aid=FAWN"
        );
        // Nothing to name the place by: the plain partner link, never a
        // guessed address that lands on nothing.
        assert_eq!(
            rental_landing_url("US", "", "Milwaukee"),
            RENTAL_COMPARE_URL
        );
        assert_eq!(rental_landing_url("US", "WI", ""), RENTAL_COMPARE_URL);
        assert_eq!(rental_landing_url("FR", "", "Paris"), RENTAL_COMPARE_URL);
        assert_eq!(
            rental_landing_url("US", "ZZ", "Milwaukee"),
            RENTAL_COMPARE_URL
        );
        // Every address carries the tag that credits the booking.
        for url in [
            rental_landing_url("US", "GA", "Augusta"),
            RENTAL_COMPARE_URL.to_string(),
        ] {
            assert!(url.contains("a_aid=FAWN"), "{url}");
            assert!(url.starts_with("https://www.discovercars.com/"), "{url}");
        }
    }

    #[test]
    fn the_relay_directory_page_gives_its_relays_with_bundled_coordinates() {
        let option = |i: usize| {
            format!(
                "<option value=\"https://radio.weatherusa.net/NWR/K{i}.mp3\"> WI-Town{i}: KEC{i} </option>"
            )
        };
        let mut html: String = (0..12).map(option).collect();
        // A repeated link, a foreign link and an empty label are skipped.
        html.push_str(&option(3));
        html.push_str("<option value=\"https://example.com/x\">X: Y</option>");
        html.push_str("<option value=\"https://radio.weatherusa.net/NWR/empty\">  </option>");
        let names = [
            "NOAA WX WI-Old: KEC3",
            "Somewhere: KEC3",
            "NOAA WX WI-Far: KEC4",
        ];
        let located = [true, true, false];
        let spans = relay_spans(&html, &names, &located).expect("twelve relays");
        assert_eq!(spans.len(), 12);
        assert_eq!(
            &html[spans[3].url.0..spans[3].url.1],
            "https://radio.weatherusa.net/NWR/K3.mp3"
        );
        assert_eq!(&html[spans[3].label.0..spans[3].label.1], "WI-Town3: KEC3");
        assert_eq!(
            spans[3].bundled,
            Some(0),
            "the first located station with the callsign"
        );
        assert_eq!(
            spans[4].bundled, None,
            "a station without coordinates carries none"
        );
        // Nine relays is a page that did not parse.
        let short: String = (0..9).map(option).collect();
        assert_eq!(relay_spans(&short, &[], &[]), None);
        assert_eq!(relay_callsign("NOAA WX AL-Mobile:  KEC61 "), Some("KEC61"));
        assert_eq!(relay_callsign("Mobile:"), Some("Mobile"));
        assert_eq!(relay_callsign("::"), None);
    }

    use super::*;

    #[test]
    fn a_pasted_coordinate_parses_in_the_forms_people_paste() {
        let at = |t: &str| parse_coordinate(t).unwrap_or_else(|| panic!("{t}"));
        assert_eq!(at("43.0731, -89.4012"), (43.0731, -89.4012));
        assert_eq!(at("43.0731N 89.4012W"), (43.0731, -89.4012));
        assert_eq!(at("N 43.0731 W 89.4012"), (43.0731, -89.4012));
        assert_eq!(at("89.4012W 43.0731N"), (43.0731, -89.4012));
        assert_eq!(at("33.8688S 151.2093E"), (-33.8688, 151.2093));
        assert_eq!(at("  43.0731 , -89.4012  "), (43.0731, -89.4012));
        for text in [
            "Madison",
            "43.0731",
            "1600 Pennsylvania Ave",
            "43.0731, -89.4012, 10",
            "91.0, -89.4",
            "43.0, -181.0",
            "43.0731N 89.4012N",
            "N43W 89.4",
            "",
            "  ",
        ] {
            assert_eq!(parse_coordinate(text), None, "{text}");
        }
    }

    #[test]
    fn a_place_used_daily_outranks_a_fresher_one_off() {
        let now = 800_000_000.0;
        let day = 86_400.0;
        assert!(recent_score(10, now - 2.0 * day, now) > recent_score(1, now - day, now));
        assert_eq!(recent_score(1, now, now).to_bits(), 1.0_f64.to_bits());
        assert_eq!(
            recent_score(2, now - 14.0 * day, now).to_bits(),
            1.0_f64.to_bits()
        );
    }

    #[test]
    fn remembering_a_place_again_counts_a_use_and_keeps_the_cap() {
        let place = |name: &str, t: f64| Recent {
            name: name.into(),
            latitude: 0.0,
            longitude: 0.0,
            last_used: t,
            uses: 1,
        };
        let now = 800_000_000.0;
        let merged = merged_recents(&[place("Home", now - 10.0)], &place("HOME", now), now);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].uses, 2);
        assert_eq!(merged[0].name, "HOME");
        let mut list = Vec::new();
        for i in 0..30 {
            list = merged_recents(&list, &place(&format!("Place {i}"), now), now);
        }
        assert_eq!(list.len(), RECENTS_CAP);
        assert_eq!(recordable_name("  Current Location "), None);
        assert_eq!(recordable_name(" Work "), Some("Work"));
        assert_eq!(
            matching_recents(&["Madison", "Sun Prairie"], " PRAIRIE", 3),
            vec![1]
        );
    }

    #[test]
    fn rentals_keep_the_nearest_office_per_brand_biggest_brand_first() {
        let names = [
            "Hertz Car Rental - Columbia Airport",
            "Hertz",
            "Enterprise Rent-A-Car",
            "Bob's Rent-a-Wreck",
            "Avis Car Rental",
        ];
        let miles = [6.2, 1.1, 0.8, 0.2, 2.5];
        assert_eq!(recommend_rentals(&names, &miles, 3), vec![2, 1, 4]);
        assert_eq!(
            recommend_rentals(&["Bob's Rentals", "Carol's Cars"], &[0.5, 0.7], 3).len(),
            2
        );
        assert_eq!(
            rental_booking_site(Some("Hertz Car Rental")),
            Some("https://www.hertz.com")
        );
        assert_eq!(rental_booking_site(Some("Bob's Rent-a-Wreck")), None);
        // Offices that do not order keep the order their brands first appeared.
        assert_eq!(
            recommend_rentals(&["Carol's Cars", "Bob's Rentals"], &[1.0, 1.0], 3),
            vec![0, 1]
        );
    }

    #[test]
    fn the_radio_reads_state_codes_and_walks_its_queue() {
        assert_eq!(
            radio_state_code("NOAA WX AL-Mobile: KEC61").as_deref(),
            Some("AL")
        );
        assert_eq!(radio_state_code("ALA-Mobile"), None);
        assert_eq!(radio_advance(2, 3, 1), 0);
        assert_eq!(radio_advance(0, 3, -1), 2);
        assert_eq!(radio_advance(5, 0, -1), 0);
        assert_eq!(radio_purpose("CB 19 (27.185 MHz)"), 0);
        assert!(radio_is_car_band("Highway Advisory 530/1610 kHz AM"));
        let (lat, _, exact) = radio_position("WI-Madison", None, None).expect("a state centre");
        assert!(!exact && lat > 42.0 && lat < 47.5);
    }
}
