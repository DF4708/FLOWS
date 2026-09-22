// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::tags_and_replies`: route tags, sensor
//! replies, spoken replies and the radio directory's rules. Functions are
//! named `flows_tags_…`.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - an optional number comes back as [`FlowsTagsNumber`]; optional text as
//!   a string that is empty for none (no answer is ever empty text);
//! - an optional argument is a value plus a `has_` flag;
//! - a list of texts crosses as one joined string plus each text's UTF-8
//!   length, with a presence flag per text where a text may be missing;
//! - stations cross as parallel columns with presence flags for their
//!   coordinates;
//! - a spoken outcome is [`FlowsTagsOutcome`]: code 0 picked, 1 switch
//!   cuisine, 2 back to cuisine, 3 declined, 4 unclear, with the index for
//!   the first two; a yes or no is `1`, `0`, or `-1` for neither;
//! - a radio kind is its declaration-order index, `-1` for none;
//! - a list that may be missing comes back with a leading `1` or `0`.
//!
//! Every column travels with its count, so the facades send a one-element
//! placeholder for an empty list: swift-bridge must never see an empty
//! buffer. Every function is a thin forwarder through [`contain`].

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

use crate::{contain, split_texts};
use ffi::{FlowsTagsNumber, FlowsTagsOutcome};
use flows_core::tags_and_replies as tr;

#[swift_bridge::bridge]
mod ffi {
    // An optional number: `value` means something only when `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsTagsNumber {
        has: bool,
        value: f64,
    }
    // A spoken outcome (module docs for the codes).
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsTagsOutcome {
        code: u8,
        index: i64,
    }

    extern "Rust" {
        // ---- route tags ----
        fn flows_tags_max_grade_percent(
            elevations: &[f64],
            present: &[u8],
            count: i64,
            spacing_meters: f64,
        ) -> FlowsTagsNumber;
        fn flows_tags_clearance_meters(tag: &str) -> FlowsTagsNumber;
        fn flows_tags_weight_limit_lbs(tag: &str) -> FlowsTagsNumber;
        fn flows_tags_is_high_risk_flood_zone(zone: &str) -> bool;
        fn flows_tags_route_constants() -> Vec<f64>;
        fn flows_tags_limits_on_route(
            route_lats: &[f64],
            route_lons: &[f64],
            way_point_counts: &[i64],
            way_lats: &[f64],
            way_lons: &[f64],
            way_tags_joined: &str,
            way_tag_lens: &[i64],
        ) -> Vec<u8>;

        // ---- sensors ----
        fn flows_tags_parse_tpms(
            name: &str,
            has_name: bool,
            data: &[u8],
            data_count: i64,
            has_data: bool,
        ) -> Vec<f64>;
        fn flows_tags_tpms_position(name: &str) -> String;
        fn flows_tags_displayed_psi(psi: f64) -> f64;
        fn flows_tags_parse_fuel_reply(line: &str) -> FlowsTagsNumber;
        fn flows_tags_looks_like_obd_adapter(name: &str) -> bool;
        fn flows_tags_low_pressure_psi() -> f64;

        // ---- spoken replies ----
        fn flows_tags_interpret_yes_no(transcript: &str) -> i64;
        fn flows_tags_wants_weather_radio(transcript: &str) -> bool;
        fn flows_tags_choose(
            reply: &str,
            options: &str,
            option_lengths: &[i64],
            option_count: i64,
        ) -> FlowsTagsOutcome;
        fn flows_tags_place_reply(
            reply: &str,
            places: &str,
            place_lengths: &[i64],
            place_count: i64,
            cuisines: &str,
            cuisine_lengths: &[i64],
            cuisine_count: i64,
        ) -> FlowsTagsOutcome;
        fn flows_tags_list_text(list: u16) -> String;
        fn flows_tags_list_lengths(list: u16) -> Vec<i64>;

        // ---- broadcast radio ----
        fn flows_tags_kind_for_tags(tags: &str) -> i64;
        fn flows_tags_match_order() -> Vec<i64>;
        fn flows_tags_dial_label(name: &str) -> String;
        fn flows_tags_ranked_stations(
            lats: &[f64],
            has_lat: &[u8],
            lons: &[f64],
            has_lon: &[u8],
            bitrates: &[i64],
            count: i64,
            lat: f64,
            lon: f64,
            has_position: bool,
        ) -> Vec<i64>;

        // ---- the radio directory ----
        fn flows_tags_is_allowed_mirror(host: &str) -> bool;
        fn flows_tags_nearby_radius_meters() -> i64;
        fn flows_tags_merged_stations(
            names: &str,
            name_lengths: &[i64],
            urls: &str,
            url_lengths: &[i64],
            name_hit_count: i64,
            has_name_hits: bool,
            tag_hit_count: i64,
            has_tag_hits: bool,
        ) -> Vec<i64>;
        fn flows_tags_kept_station_rows(
            names: &str,
            name_lengths: &[i64],
            has_name: &[u8],
            urls: &str,
            url_lengths: &[i64],
            has_url: &[u8],
            count: i64,
        ) -> Vec<i64>;
        fn flows_tags_station_name(name: &str) -> String;
        fn flows_tags_unique_server_names(
            names: &str,
            lengths: &[i64],
            present: &[u8],
            count: i64,
        ) -> Vec<i64>;
        fn flows_tags_genre_words(tags: &str) -> String;
        fn flows_tags_state_name(code: &str) -> String;
        fn flows_tags_ranked_nearest(
            lats: &[f64],
            has_lat: &[u8],
            lons: &[f64],
            has_lon: &[u8],
            votes: &[i64],
            urls: &str,
            url_lengths: &[i64],
            count: i64,
            lat: f64,
            lon: f64,
        ) -> Vec<i64>;
    }
}

/// `flows_tags_list_text` and `flows_tags_list_lengths`: the yes words.
pub const LIST_YES: u16 = 0;
/// The no words.
pub const LIST_NO: u16 = 1;
/// The back-words.
pub const LIST_BACK: u16 = 2;
/// The directory's common genres.
pub const LIST_COMMON_GENRES: u16 = 3;
/// The allowed mirror countries, sorted.
pub const LIST_MIRROR_COUNTRIES: u16 = 4;
/// The tag words of the kind at `list - LIST_KIND_TAGS` (declaration order).
pub const LIST_KIND_TAGS: u16 = 100;

// ------------------------------------------------------------------ helpers

/// A count from Swift as a length no longer than `available`.
fn clamp(count: i64, available: usize) -> usize {
    usize::try_from(count).unwrap_or(0).min(available)
}

/// An index for Swift.
fn index(i: usize) -> i64 {
    i64::try_from(i).unwrap_or(i64::MAX)
}

/// A list of indices for Swift.
fn indices(list: Vec<usize>) -> Vec<i64> {
    list.into_iter().map(index).collect()
}

/// An optional number for Swift.
fn number(value: Option<f64>) -> FlowsTagsNumber {
    FlowsTagsNumber {
        has: value.is_some(),
        value: value.unwrap_or(0.0),
    }
}

/// No number.
const NO_NUMBER: FlowsTagsNumber = FlowsTagsNumber {
    has: false,
    value: 0.0,
};

/// The first `count` texts of a joined column, or `None` when the lengths do
/// not split it.
fn texts<'a>(joined: &'a str, lengths: &[i64], count: i64) -> Option<Vec<&'a str>> {
    split_texts(joined, lengths, clamp(count, lengths.len()))
}

/// The first `count` optional texts of a joined column with presence flags.
fn optional_texts<'a>(
    joined: &'a str,
    lengths: &[i64],
    present: &[u8],
    count: i64,
) -> Option<Vec<Option<&'a str>>> {
    let n = clamp(count, present.len());
    let all = split_texts(joined, lengths, clamp(count, lengths.len()))?;
    Some(
        all.into_iter()
            .take(n)
            .enumerate()
            .map(|(i, t)| (present[i] != 0).then_some(t))
            .collect(),
    )
}

/// The first `count` stations from their columns.
fn stations(
    lats: &[f64],
    has_lat: &[u8],
    lons: &[f64],
    has_lon: &[u8],
    bitrates: &[i64],
    count: i64,
) -> Vec<tr::RadioStation> {
    let n = clamp(
        count,
        lats.len()
            .min(has_lat.len())
            .min(lons.len())
            .min(has_lon.len())
            .min(bitrates.len()),
    );
    (0..n)
        .map(|i| tr::RadioStation {
            lat: (has_lat[i] != 0).then_some(lats[i]),
            lon: (has_lon[i] != 0).then_some(lons[i]),
            bitrate: bitrates[i],
        })
        .collect()
}

/// A spoken pick for Swift.
fn pick(outcome: tr::PickOutcome) -> FlowsTagsOutcome {
    match outcome {
        tr::PickOutcome::Picked(i) => FlowsTagsOutcome {
            code: 0,
            index: index(i),
        },
        tr::PickOutcome::Declined => FlowsTagsOutcome { code: 3, index: -1 },
        tr::PickOutcome::Unclear => UNCLEAR,
    }
}

/// Unclear: nothing is guessed.
const UNCLEAR: FlowsTagsOutcome = FlowsTagsOutcome { code: 4, index: -1 };

// ------------------------------------------------------------------ route tags

/// `tr::max_grade_percent` over the first `count` samples. A panic answers none.
pub fn flows_tags_max_grade_percent(
    elevations: &[f64],
    present: &[u8],
    count: i64,
    spacing_meters: f64,
) -> FlowsTagsNumber {
    contain(NO_NUMBER, || {
        let n = clamp(count, elevations.len().min(present.len()));
        let samples: Vec<Option<f64>> = (0..n)
            .map(|i| (present[i] != 0).then_some(elevations[i]))
            .collect();
        number(tr::max_grade_percent(&samples, spacing_meters))
    })
}

/// `tr::clearance_meters`. A panic answers none.
pub fn flows_tags_clearance_meters(tag: &str) -> FlowsTagsNumber {
    contain(NO_NUMBER, || number(tr::clearance_meters(tag)))
}

/// `tr::weight_limit_lbs`. A panic answers none.
pub fn flows_tags_weight_limit_lbs(tag: &str) -> FlowsTagsNumber {
    contain(NO_NUMBER, || number(tr::weight_limit_lbs(tag)))
}

/// `tr::is_high_risk_flood_zone`. A panic answers false: unknown is not risky.
pub fn flows_tags_is_high_risk_flood_zone(zone: &str) -> bool {
    contain(false, || tr::is_high_risk_flood_zone(zone))
}

/// For each restricted way (its points in order, `way_point_counts` per way;
/// its tags as `key=value` pairs joined by U+001F, one string per way in
/// `way_tags_joined` with byte lengths `way_tag_lens`): 1 when its posted
/// limit restricts the route, else 0. Input that doesn't add up, and
/// containment, count every way: missing a real low bridge is worse than an
/// extra warning.
pub fn flows_tags_limits_on_route(
    route_lats: &[f64],
    route_lons: &[f64],
    way_point_counts: &[i64],
    way_lats: &[f64],
    way_lons: &[f64],
    way_tags_joined: &str,
    way_tag_lens: &[i64],
) -> Vec<u8> {
    let n = way_point_counts.len();
    contain(vec![1; n], || {
        let everything = vec![1; n];
        let Some(tag_texts) = split_texts(way_tags_joined, way_tag_lens, n) else {
            return everything;
        };
        let route: Vec<tr::Point> = route_lats
            .iter()
            .zip(route_lons)
            .map(|(&a, &b)| (a, b))
            .collect();
        let mut lines: Vec<Vec<tr::Point>> = Vec::with_capacity(n);
        let mut at = 0usize;
        for &count in way_point_counts {
            let Ok(count) = usize::try_from(count) else {
                return everything;
            };
            let Some(end) = at
                .checked_add(count)
                .filter(|&e| e <= way_lats.len() && e <= way_lons.len())
            else {
                return everything;
            };
            lines.push((at..end).map(|i| (way_lats[i], way_lons[i])).collect());
            at = end;
        }
        let ways: Vec<tr::RestrictedWay> = lines
            .iter()
            .zip(&tag_texts)
            .map(|(line, text)| {
                let tags = text
                    .split('\u{1F}')
                    .filter_map(|pair| pair.split_once('='))
                    .collect();
                (line.as_slice(), tags)
            })
            .collect();
        tr::limits_on_route(&route, &ways)
            .into_iter()
            .map(u8::from)
            .collect()
    })
}

/// `[LOW_CLEARANCE_THRESHOLD_METERS, WEIGHT_LIMIT_CAP_LBS]`.
pub fn flows_tags_route_constants() -> Vec<f64> {
    vec![tr::LOW_CLEARANCE_THRESHOLD_METERS, tr::WEIGHT_LIMIT_CAP_LBS]
}

// ------------------------------------------------------------------ sensors

/// `tr::parse_tpms_advertisement` as `[psi, celsius]`, empty for none; the
/// first `data_count` bytes are the data. A panic answers none.
pub fn flows_tags_parse_tpms(
    name: &str,
    has_name: bool,
    data: &[u8],
    data_count: i64,
    has_data: bool,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let bytes = &data[..clamp(data_count, data.len())];
        tr::parse_tpms_advertisement(has_name.then_some(name), has_data.then_some(bytes))
            .map_or_else(Vec::new, |r| vec![r.psi, r.celsius])
    })
}

/// The tire position `tr::parse_tpms_advertisement` reads from a name: its
/// fifth cluster, or `?`. A panic answers `?`.
pub fn flows_tags_tpms_position(name: &str) -> String {
    contain("?".to_string(), || {
        flows_core::swift_text::graphemes(name)
            .nth(4)
            .unwrap_or("?")
            .to_string()
    })
}

/// `tr::displayed_psi`. A panic answers the reading unrounded.
pub fn flows_tags_displayed_psi(psi: f64) -> f64 {
    contain(psi, || tr::displayed_psi(psi))
}

/// `tr::parse_fuel_reply`. A panic answers none.
pub fn flows_tags_parse_fuel_reply(line: &str) -> FlowsTagsNumber {
    contain(NO_NUMBER, || number(tr::parse_fuel_reply(line)))
}

/// `tr::looks_like_obd_adapter`. A panic answers false.
pub fn flows_tags_looks_like_obd_adapter(name: &str) -> bool {
    contain(false, || tr::looks_like_obd_adapter(name))
}

/// `tr::LOW_PRESSURE_PSI`.
pub fn flows_tags_low_pressure_psi() -> f64 {
    tr::LOW_PRESSURE_PSI
}

// ------------------------------------------------------------------ spoken replies

/// `tr::interpret_yes_no` as `1`, `0` or `-1`. A panic answers neither.
pub fn flows_tags_interpret_yes_no(transcript: &str) -> i64 {
    contain(-1, || match tr::interpret_yes_no(transcript) {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    })
}

/// `tr::wants_weather_radio`. A panic answers false.
pub fn flows_tags_wants_weather_radio(transcript: &str) -> bool {
    contain(false, || tr::wants_weather_radio(transcript))
}

/// `tr::choose` over the first `option_count` options. A panic, or lengths
/// that do not split the options, answer unclear.
pub fn flows_tags_choose(
    reply: &str,
    options: &str,
    option_lengths: &[i64],
    option_count: i64,
) -> FlowsTagsOutcome {
    contain(UNCLEAR, || {
        texts(options, option_lengths, option_count)
            .map_or(UNCLEAR, |list| pick(tr::choose(reply, &list)))
    })
}

/// `tr::place_reply`. A panic, or lengths that do not split a list, answer
/// unclear.
pub fn flows_tags_place_reply(
    reply: &str,
    places: &str,
    place_lengths: &[i64],
    place_count: i64,
    cuisines: &str,
    cuisine_lengths: &[i64],
    cuisine_count: i64,
) -> FlowsTagsOutcome {
    contain(UNCLEAR, || {
        let (Some(places), Some(cuisines)) = (
            texts(places, place_lengths, place_count),
            texts(cuisines, cuisine_lengths, cuisine_count),
        ) else {
            return UNCLEAR;
        };
        match tr::place_reply(reply, &places, &cuisines) {
            tr::PlaceOutcome::Picked(i) => FlowsTagsOutcome {
                code: 0,
                index: index(i),
            },
            tr::PlaceOutcome::SwitchCuisine(i) => FlowsTagsOutcome {
                code: 1,
                index: index(i),
            },
            tr::PlaceOutcome::BackToCuisine => FlowsTagsOutcome { code: 2, index: -1 },
            tr::PlaceOutcome::Declined => FlowsTagsOutcome { code: 3, index: -1 },
            tr::PlaceOutcome::Unclear => UNCLEAR,
        }
    })
}

/// A word list by number (the `LIST_…` constants); empty for an unknown one.
fn list(which: u16) -> &'static [&'static str] {
    match which {
        LIST_YES => &tr::YES_WORDS,
        LIST_NO => &tr::NO_WORDS,
        LIST_BACK => &tr::BACK_WORDS,
        LIST_COMMON_GENRES => &tr::COMMON_GENRES,
        LIST_MIRROR_COUNTRIES => &tr::ALLOWED_MIRROR_COUNTRIES,
        k => k
            .checked_sub(LIST_KIND_TAGS)
            .and_then(|i| tr::RadioKind::ALL.get(usize::from(i)))
            .map_or(&[], |kind| kind.tag_words()),
    }
}

/// A word list's texts, joined (split by [`flows_tags_list_lengths`]).
pub fn flows_tags_list_text(list_number: u16) -> String {
    list(list_number).concat()
}

/// A word list's UTF-8 lengths, in order.
pub fn flows_tags_list_lengths(list_number: u16) -> Vec<i64> {
    list(list_number).iter().map(|w| index(w.len())).collect()
}

// ------------------------------------------------------------------ broadcast radio

/// `tr::kind_for_tags` as the kind's declaration-order index, `-1` for none.
/// A panic answers none.
pub fn flows_tags_kind_for_tags(tags: &str) -> i64 {
    contain(-1, || {
        tr::kind_for_tags(tags)
            .and_then(|k| tr::RadioKind::ALL.iter().position(|&x| x == k))
            .map_or(-1, index)
    })
}

/// `RadioKind::MATCH_ORDER` as declaration-order indices.
pub fn flows_tags_match_order() -> Vec<i64> {
    tr::RadioKind::MATCH_ORDER
        .iter()
        .filter_map(|k| tr::RadioKind::ALL.iter().position(|x| x == k))
        .map(index)
        .collect()
}

/// `tr::dial_label`, empty for none. A panic answers none.
pub fn flows_tags_dial_label(name: &str) -> String {
    contain(String::new(), || tr::dial_label(name).unwrap_or_default())
}

/// `tr::ranked_stations` over the first `count` stations. A panic answers the
/// stations in their given order.
pub fn flows_tags_ranked_stations(
    lats: &[f64],
    has_lat: &[u8],
    lons: &[f64],
    has_lon: &[u8],
    bitrates: &[i64],
    count: i64,
    lat: f64,
    lon: f64,
    has_position: bool,
) -> Vec<i64> {
    let list = stations(lats, has_lat, lons, has_lon, bitrates, count);
    let given = indices((0..list.len()).collect());
    contain(given, || {
        indices(tr::ranked_stations(
            &list,
            has_position.then_some((lat, lon)),
        ))
    })
}

// ------------------------------------------------------------------ the radio directory

/// `tr::is_allowed_mirror`. A panic answers false: an unknown mirror is not
/// used.
pub fn flows_tags_is_allowed_mirror(host: &str) -> bool {
    contain(false, || tr::is_allowed_mirror(host))
}

/// `tr::NEARBY_RADIUS_METERS`.
pub fn flows_tags_nearby_radius_meters() -> i64 {
    tr::NEARBY_RADIUS_METERS
}

/// `tr::merged_stations` over the name hits followed by the tag hits, as
/// `[1, indices…]`, or `[0]` when both searches failed. A panic, or lengths
/// that do not split the columns, answer `[0]`.
pub fn flows_tags_merged_stations(
    names: &str,
    name_lengths: &[i64],
    urls: &str,
    url_lengths: &[i64],
    name_hit_count: i64,
    has_name_hits: bool,
    tag_hit_count: i64,
    has_tag_hits: bool,
) -> Vec<i64> {
    contain(vec![0], || {
        let hits = clamp(name_hit_count, usize::MAX);
        let total = hits.saturating_add(clamp(tag_hit_count, usize::MAX));
        let count = i64::try_from(total).unwrap_or(0);
        let (Some(names), Some(urls)) = (
            texts(names, name_lengths, count),
            texts(urls, url_lengths, count),
        ) else {
            return vec![0];
        };
        if names.len() != total || urls.len() != total {
            return vec![0];
        }
        let all: Vec<tr::DirectoryStation<'_>> = names
            .iter()
            .zip(&urls)
            .map(|(name, url)| tr::DirectoryStation { name, url })
            .collect();
        let (name_part, tag_part) = all.split_at(hits);
        match tr::merged_stations(
            has_name_hits.then_some(name_part),
            has_tag_hits.then_some(tag_part),
        ) {
            Some(kept) => std::iter::once(1).chain(indices(kept)).collect(),
            None => vec![0],
        }
    })
}

/// `tr::kept_station_rows`' indices over the first `count` rows. A panic, or
/// lengths that do not split the columns, answer no rows.
pub fn flows_tags_kept_station_rows(
    names: &str,
    name_lengths: &[i64],
    has_name: &[u8],
    urls: &str,
    url_lengths: &[i64],
    has_url: &[u8],
    count: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let (Some(names), Some(urls)) = (
            optional_texts(names, name_lengths, has_name, count),
            optional_texts(urls, url_lengths, has_url, count),
        ) else {
            return Vec::new();
        };
        let rows: Vec<tr::DirectoryRow<'_>> = names
            .iter()
            .zip(&urls)
            .map(|(&name, &url)| tr::DirectoryRow { name, url })
            .collect();
        indices(
            tr::kept_station_rows(&rows)
                .into_iter()
                .map(|(i, _)| i)
                .collect(),
        )
    })
}

/// A kept station's name as the directory list shows it: trimmed of
/// whitespace and newlines. A panic answers the name as given.
pub fn flows_tags_station_name(name: &str) -> String {
    contain(name.to_string(), || {
        flows_core::swift_text::trim_whitespace_newlines(name).to_string()
    })
}

/// `tr::unique_server_names` over the first `count` names. A panic, or
/// lengths that do not split the column, answer no names.
pub fn flows_tags_unique_server_names(
    names: &str,
    lengths: &[i64],
    present: &[u8],
    count: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        optional_texts(names, lengths, present, count)
            .map_or_else(Vec::new, |list| indices(tr::unique_server_names(&list)))
    })
}

/// `tr::genre_words`. A panic answers no genre.
pub fn flows_tags_genre_words(tags: &str) -> String {
    contain(String::new(), || tr::genre_words(tags))
}

/// `tr::state_name`, empty for none. A panic answers none.
pub fn flows_tags_state_name(code: &str) -> String {
    contain(String::new(), || {
        tr::state_name(code).unwrap_or_default().to_string()
    })
}

/// `tr::ranked_nearest` over the first `count` stations. A panic, or lengths
/// that do not split the URLs, answer the stations in their given order.
pub fn flows_tags_ranked_nearest(
    lats: &[f64],
    has_lat: &[u8],
    lons: &[f64],
    has_lon: &[u8],
    votes: &[i64],
    urls: &str,
    url_lengths: &[i64],
    count: i64,
    lat: f64,
    lon: f64,
) -> Vec<i64> {
    let list = stations(lats, has_lat, lons, has_lon, votes, count);
    let given = indices((0..list.len()).collect());
    contain(given.clone(), || {
        let Some(urls) = texts(urls, url_lengths, count) else {
            return given;
        };
        indices(tr::ranked_nearest(&list, &urls, (lat, lon)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_round_trip_through_their_lengths() {
        for which in [
            LIST_YES,
            LIST_NO,
            LIST_BACK,
            LIST_COMMON_GENRES,
            LIST_MIRROR_COUNTRIES,
            LIST_KIND_TAGS + 8,
        ] {
            let joined = flows_tags_list_text(which);
            let lengths = flows_tags_list_lengths(which);
            let count = i64::try_from(lengths.len()).expect("small");
            assert_eq!(
                texts(&joined, &lengths, count).expect("splits"),
                list(which)
            );
        }
        assert!(flows_tags_list_lengths(LIST_KIND_TAGS + 11).is_empty());
        assert!(flows_tags_list_text(LIST_KIND_TAGS + 8).contains("espa\u{F1}ol"));
    }

    #[test]
    fn outcomes_and_optionals_use_their_documented_codes() {
        let options = "El RaysTaco Bell";
        let lengths = [7, 9];
        let got = flows_tags_choose("taco bell please", options, &lengths, 2);
        assert_eq!((got.code, got.index), (0, 1));
        let none = flows_tags_choose("hmm", options, &lengths, 2);
        assert_eq!((none.code, none.index), (4, -1));
        let place =
            flows_tags_place_reply("actually Mexican", "Taco Bell", &[9], 1, "Mexican", &[7], 1);
        assert_eq!((place.code, place.index), (1, 0));
        assert_eq!(flows_tags_interpret_yes_no("nope"), 0);
        assert!(!flows_tags_clearance_meters("default").has);
        assert!(flows_tags_parse_tpms("TPMS1", true, &[0], 0, true).is_empty());
        assert_eq!(
            flows_tags_merged_stations("", &[0], "", &[0], 0, false, 0, false),
            vec![0]
        );
        assert_eq!(
            flows_tags_merged_stations("", &[0], "", &[0], 0, true, 0, false),
            vec![1]
        );
        assert_eq!(flows_tags_state_name("zz"), "");
        assert_eq!(flows_tags_kind_for_tags("christian rock"), 10);
    }
}
